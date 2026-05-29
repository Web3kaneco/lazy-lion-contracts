// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ILionLedger} from "./interfaces/ILionLedger.sol";

/// @title LionSubscription
/// @notice ERC-5643-style paid subscription NFTs per Lion. A holder
///         enables a paid tier on their Lion by registering a price
///         and duration. Subscribers pay USDC to mint a subscription
///         NFT that gates access to the Lion's chat + premium content.
///
/// @dev Revenue split is a contract constant (90% holder / 5% platform
///      / 5% treasury) in v1. USDC flows into this contract on each
///      purchase, then immediately distributed; unrouted funds (e.g.
///      a holder address that rejects ERC-20) credit into `unclaimed`
///      and the recipient pulls via `claim()`.
///
///      Subscription NFTs are transferable by default so secondary
///      market resale of the unused remainder works on any marketplace.
///      Holders can disable transferability per-tier if they prefer.
///
///      Accepted design choices (audit LOW-9, LOW-10):
///        - A subscriber may hold multiple active sub NFTs for the
///          same Lion. Each is independently transferable.
///        - Tier transferability is checked on every transfer (one
///          extra SLOAD); acceptable on Base.
contract LionSubscription is ERC721, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // --- Constants ---------------------------------------------------

    uint16 public constant HOLDER_BPS = 9000; // 90%
    uint16 public constant PLATFORM_BPS = 500; // 5%
    uint16 public constant TREASURY_BPS = 500; // 5%
    uint16 public constant TOTAL_BPS = 10000;

    // --- Storage -----------------------------------------------------

    /// @notice Per-Lion subscription tier configuration.
    struct Tier {
        /// Holder of the mainnet Lion at the time of registration
        address holderPayee;
        /// USDC price per period (6 decimals)
        uint128 pricePerPeriod;
        /// Period length in seconds (e.g. 30 days)
        uint64 periodSeconds;
        /// Whether the tier is currently sellable
        bool enabled;
        /// Whether subscription NFTs can be transferred
        bool transferable;
    }

    /// @dev tier[mainnetCollection][tokenId]
    mapping(address => mapping(uint256 => Tier)) public tiers;

    /// @notice Per-sub-NFT data
    struct Subscription {
        address mainnetCollection;
        uint256 mainnetTokenId;
        uint64 startedAt;
        uint64 expiresAt;
    }
    mapping(uint256 => Subscription) public subs;

    IERC20 public immutable paymentToken;
    address public platformRecipient;
    address public treasuryRecipient;
    address public operator;
    ILionLedger public ledger;

    uint256 private _nextTokenId;

    // --- Events ------------------------------------------------------

    event TierRegistered(
        address indexed mainnetCollection,
        uint256 indexed tokenId,
        address indexed holderPayee,
        uint128 pricePerPeriod,
        uint64 periodSeconds
    );
    event TierUpdated(address indexed mainnetCollection, uint256 indexed tokenId);
    event SubscriptionPurchased(
        uint256 indexed subscriptionId,
        address indexed subscriber,
        address indexed mainnetCollection,
        uint256 mainnetTokenId,
        uint64 expiresAt,
        uint256 amountPaid
    );
    event SubscriptionRenewed(
        uint256 indexed subscriptionId,
        uint64 newExpiresAt,
        uint256 amountPaid
    );
    event LedgerWriteFailed(
        address indexed mainnetCollection,
        uint256 indexed mainnetTokenId
    );

    // --- Errors ------------------------------------------------------

    error TierNotEnabled();
    error NotTierHolder();
    error InvalidPeriods();
    error NotOperator();
    error CostExceedsMax(uint256 actual, uint256 max);
    error InvalidRecipient();
    error NotTransferable();

    // --- Construction ------------------------------------------------

    constructor(
        address initialOwner,
        IERC20 paymentToken_,
        address platformRecipient_,
        address treasuryRecipient_,
        address initialOperator,
        ILionLedger initialLedger
    )
        ERC721("Lazy Lion Subscription", "LLS")
        Ownable(initialOwner)
    {
        paymentToken = paymentToken_;
        platformRecipient = platformRecipient_;
        treasuryRecipient = treasuryRecipient_;
        operator = initialOperator;
        ledger = initialLedger;
        _nextTokenId = 1;
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

    /// @notice Update the payee for a tier. Called when ownership of
    ///         the mainnet Lion transfers. Operator-only; the operator
    ///         verifies the new holder before submitting.
    /// @dev MED-6 fix: stale payouts after Lion sale. This rotation is
    ///      intentionally instant (no timelock) because it must follow
    ///      a mainnet Lion sale immediately. a delay would route the new
    ///      owner's subscription revenue to the previous holder for the
    ///      duration of the timelock. The operator is trusted to verify
    ///      ownership before calling, same trust assumption as registerTier.
    function updateHolderPayee(
        address mainnetCollection,
        uint256 tokenId,
        address newHolderPayee
    ) external {
        if (msg.sender != operator) revert NotOperator();
        if (newHolderPayee == address(0)) revert InvalidRecipient();
        tiers[mainnetCollection][tokenId].holderPayee = newHolderPayee;
        emit TierUpdated(mainnetCollection, tokenId);
    }

    // --- Tier registration (called via operator after holder signs) --

    /// @notice Register or update a subscription tier for a Lion.
    /// @dev Operator-only. The operator must have verified the caller's
    ///      mainnet ownership of the Lion before submitting. Holder
    ///      payee is captured here and used for all future payouts.
    function registerTier(
        address mainnetCollection,
        uint256 tokenId,
        address holderPayee,
        uint128 pricePerPeriod,
        uint64 periodSeconds,
        bool transferable
    ) external {
        if (msg.sender != operator) revert NotOperator();
        if (periodSeconds == 0) revert InvalidPeriods();

        Tier storage t = tiers[mainnetCollection][tokenId];
        t.holderPayee = holderPayee;
        t.pricePerPeriod = pricePerPeriod;
        t.periodSeconds = periodSeconds;
        t.enabled = true;
        t.transferable = transferable;

        emit TierRegistered(
            mainnetCollection,
            tokenId,
            holderPayee,
            pricePerPeriod,
            periodSeconds
        );
    }

    function disableTier(address mainnetCollection, uint256 tokenId) external {
        if (msg.sender != operator) revert NotOperator();
        tiers[mainnetCollection][tokenId].enabled = false;
        emit TierUpdated(mainnetCollection, tokenId);
    }

    // --- Purchase / renew --------------------------------------------

    function purchase(
        address mainnetCollection,
        uint256 mainnetTokenId,
        uint256 periods,
        uint256 maxCostExpected
    ) external nonReentrant returns (uint256 subscriptionId) {
        if (periods == 0) revert InvalidPeriods();
        Tier memory t = tiers[mainnetCollection][mainnetTokenId];
        if (!t.enabled) revert TierNotEnabled();

        uint256 totalCost = uint256(t.pricePerPeriod) * periods;
        // MED-7: slippage protection. Caller asserts max they'll pay.
        if (totalCost > maxCostExpected) {
            revert CostExceedsMax(totalCost, maxCostExpected);
        }
        _collectAndSplit(msg.sender, t.holderPayee, totalCost);

        uint64 duration = uint64(uint256(t.periodSeconds) * periods);
        subscriptionId = _nextTokenId++;
        subs[subscriptionId] = Subscription({
            mainnetCollection: mainnetCollection,
            mainnetTokenId: mainnetTokenId,
            startedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + duration
        });
        _safeMint(msg.sender, subscriptionId);

        if (address(ledger) != address(0)) {
            try ledger.recordSubscriptionChange(
                mainnetCollection,
                mainnetTokenId,
                int32(1),
                ILionLedger.EventType.SubscriptionStarted,
                bytes32(subscriptionId)
            ) {} catch {
                emit LedgerWriteFailed(mainnetCollection, mainnetTokenId);
            }
        }

        emit SubscriptionPurchased(
            subscriptionId,
            msg.sender,
            mainnetCollection,
            mainnetTokenId,
            subs[subscriptionId].expiresAt,
            totalCost
        );
    }

    function renew(
        uint256 subscriptionId,
        uint256 periods,
        uint256 maxCostExpected
    ) external nonReentrant {
        if (periods == 0) revert InvalidPeriods();
        Subscription storage s = subs[subscriptionId];
        Tier memory t = tiers[s.mainnetCollection][s.mainnetTokenId];
        if (!t.enabled) revert TierNotEnabled();

        uint256 totalCost = uint256(t.pricePerPeriod) * periods;
        if (totalCost > maxCostExpected) {
            revert CostExceedsMax(totalCost, maxCostExpected);
        }
        _collectAndSplit(msg.sender, t.holderPayee, totalCost);

        uint64 base = s.expiresAt > uint64(block.timestamp)
            ? s.expiresAt
            : uint64(block.timestamp);
        s.expiresAt = base + uint64(uint256(t.periodSeconds) * periods);

        if (address(ledger) != address(0)) {
            try ledger.recordSubscriptionChange(
                s.mainnetCollection,
                s.mainnetTokenId,
                int32(0),
                ILionLedger.EventType.SubscriptionRenewed,
                bytes32(subscriptionId)
            ) {} catch {
                emit LedgerWriteFailed(s.mainnetCollection, s.mainnetTokenId);
            }
        }

        emit SubscriptionRenewed(subscriptionId, s.expiresAt, totalCost);
    }

    function isActive(uint256 subscriptionId) external view returns (bool) {
        return subs[subscriptionId].expiresAt > block.timestamp;
    }

    // --- ERC-5643 compatibility --------------------------------------

    /// @notice ERC-5643: expiration timestamp for a subscription token.
    function expiresAt(uint256 tokenId) external view returns (uint64) {
        return subs[tokenId].expiresAt;
    }

    /// @notice ERC-5643: whether the tier backing this token still
    ///         allows renewals.
    function isRenewable(uint256 tokenId) external view returns (bool) {
        Subscription memory s = subs[tokenId];
        return tiers[s.mainnetCollection][s.mainnetTokenId].enabled;
    }

    // --- Internals ---------------------------------------------------

    /// @dev HIGH-3 fix: pull-then-distribute so one bad recipient
    ///      can't block the whole purchase. We pull total into this
    ///      contract once, then push to three recipients with
    ///      try-style transfers. Funds for a failing recipient credit
    ///      into `unclaimed` for later withdrawal by the owner.
    mapping(address => uint256) public unclaimed;

    event PayoutDeferred(address indexed recipient, uint256 amount, string reason);

    function _collectAndSplit(address payer, address holder, uint256 total) internal {
        uint256 holderCut = (total * HOLDER_BPS) / TOTAL_BPS;
        uint256 platformCut = (total * PLATFORM_BPS) / TOTAL_BPS;
        uint256 treasuryCut = total - holderCut - platformCut;

        paymentToken.safeTransferFrom(payer, address(this), total);
        _payOrDefer(holder, holderCut);
        if (platformCut > 0) _payOrDefer(platformRecipient, platformCut);
        if (treasuryCut > 0) _payOrDefer(treasuryRecipient, treasuryCut);
    }

    function _payOrDefer(address recipient, uint256 amount) internal {
        if (recipient == address(0)) {
            unclaimed[address(this)] += amount;
            emit PayoutDeferred(address(0), amount, "zero address");
            return;
        }
        // Use low-level call via SafeERC20.trySafeTransfer-style pattern.
        // OZ's SafeERC20 doesn't expose a try variant, so wrap in try/catch
        // by calling through an internal helper.
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

    /// @notice Recipient pulls funds that were deferred during purchase.
    function claim() external nonReentrant {
        uint256 amount = unclaimed[msg.sender];
        if (amount == 0) return;
        unclaimed[msg.sender] = 0;
        paymentToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Owner-only recovery for funds deferred to address(0).
    function sweepZeroAddress(address to) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        uint256 amount = unclaimed[address(this)];
        unclaimed[address(this)] = 0;
        if (amount > 0) paymentToken.safeTransfer(to, amount);
    }

    /// @dev Enforce per-tier transferability. Mint + burn always allowed.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address from)
    {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) {
            Subscription memory s = subs[tokenId];
            Tier memory t = tiers[s.mainnetCollection][s.mainnetTokenId];
            if (!t.transferable) revert NotTransferable();
        }
    }
}
