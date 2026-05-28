// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILionLedger} from "./interfaces/ILionLedger.sol";

/// @title LionLedger
/// @notice Append-only activity log + per-Lion counters for Lazy Lion
///         agents. Every action a holder takes through the LazyLionAgents
///         site (or through any authorized integration) writes here.
///
/// @dev Trust model: a small set of authorized "operators" submit events.
///      The LazyLionAgents backend wallet is the v0 operator; it has
///      already verified the caller's mainnet ownership of the Lion
///      before submitting. Adding holder-direct writes with signature
///      verification is a future extension. not needed for v0.
///
///      Operators are TRUSTED. They can spam events (and thus inflate
///      earned-level scores) for any Lion. Mitigations:
///        - Owner restricts operator set to the LazyLionAgents backend
///          + internal integrations only.
///        - Operator wallets should be KMS-held (see HIGH-4 in audit).
///        - Per-block event volume is not capped on-contract; add a
///          rate limit at the operator service level.
///        - If operator compromise is suspected, owner can call
///          setOperator(operator, false) to revoke. Past events stay
///          recorded but new writes stop.
///
///      Storage is intentionally minimal. Events carry the rich data
///      (subgraphs index them); state stores only the counters the
///      EvolutionOracle needs to compute earned level on chain.
contract LionLedger is ILionLedger, Ownable {
    // --- Storage -----------------------------------------------------

    /// @dev counters[collection][tokenId]
    mapping(address => mapping(uint256 => Counters)) private _counters;

    /// @dev operator → authorized?
    mapping(address => bool) public isOperator;

    /// @dev Hard cap on metadata size to keep gas predictable.
    uint256 public constant MAX_METADATA_BYTES = 1024;

    // --- Events ------------------------------------------------------

    event OperatorSet(address indexed operator, bool authorized);

    // --- Errors ------------------------------------------------------

    error NotOperator(address caller);
    error MetadataTooLarge(uint256 length);

    // --- Construction ------------------------------------------------

    /// @param initialOwner The address that can manage operators
    /// @param initialOperator The first operator (typically the
    ///                        LazyLionAgents backend wallet)
    constructor(address initialOwner, address initialOperator) Ownable(initialOwner) {
        isOperator[initialOperator] = true;
        emit OperatorSet(initialOperator, true);
    }

    // --- Modifiers ---------------------------------------------------

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert NotOperator(msg.sender);
        _;
    }

    // --- Operator management -----------------------------------------

    function setOperator(address operator, bool authorized) external onlyOwner {
        isOperator[operator] = authorized;
        emit OperatorSet(operator, authorized);
    }

    // --- Writes ------------------------------------------------------

    /// @inheritdoc ILionLedger
    function record(
        address mainnetCollection,
        uint256 tokenId,
        EventType eventType,
        bytes32 payload,
        bytes calldata metadata
    ) external onlyOperator {
        if (metadata.length > MAX_METADATA_BYTES) {
            revert MetadataTooLarge(metadata.length);
        }
        Counters storage c = _counters[mainnetCollection][tokenId];
        if (c.firstSeenAt == 0) c.firstSeenAt = uint64(block.timestamp);
        c.lastEventAt = uint64(block.timestamp);

        // Increment the matching counter
        if (eventType == EventType.PickMade) c.picksMade += 1;
        else if (eventType == EventType.JournalEntry) c.journalEntries += 1;
        else if (eventType == EventType.SwarmVerdict) c.swarmVerdicts += 1;
        else if (eventType == EventType.ArtMinted) c.artMinted += 1;
        else if (eventType == EventType.ToolAuthorized) c.toolsAuthorized += 1;
        // PickSettled and Subscription* are routed through helpers below
        // because they update multiple counters atomically.

        emit LionEvent(
            mainnetCollection,
            tokenId,
            eventType,
            msg.sender,
            payload,
            metadata,
            uint64(block.timestamp)
        );
    }

    /// @inheritdoc ILionLedger
    function recordPickSettled(
        address mainnetCollection,
        uint256 tokenId,
        bool won,
        bytes32 payload,
        bytes calldata metadata
    ) external onlyOperator {
        if (metadata.length > MAX_METADATA_BYTES) {
            revert MetadataTooLarge(metadata.length);
        }
        Counters storage c = _counters[mainnetCollection][tokenId];
        if (c.firstSeenAt == 0) c.firstSeenAt = uint64(block.timestamp);
        c.lastEventAt = uint64(block.timestamp);
        c.picksSettled += 1;
        if (won) c.picksWon += 1;

        emit LionEvent(
            mainnetCollection,
            tokenId,
            EventType.PickSettled,
            msg.sender,
            payload,
            metadata,
            uint64(block.timestamp)
        );
    }

    /// @inheritdoc ILionLedger
    function recordSubscriptionChange(
        address mainnetCollection,
        uint256 tokenId,
        int32 activeDelta,
        EventType eventType,
        bytes32 payload
    ) external onlyOperator {
        Counters storage c = _counters[mainnetCollection][tokenId];
        if (c.firstSeenAt == 0) c.firstSeenAt = uint64(block.timestamp);
        c.lastEventAt = uint64(block.timestamp);

        if (eventType == EventType.SubscriptionStarted) {
            c.subscribersTotal += 1;
        }
        if (activeDelta > 0) {
            c.subscribersActive += _absI32(activeDelta);
        } else if (activeDelta < 0) {
            uint32 dec = _absI32(activeDelta);
            c.subscribersActive = c.subscribersActive > dec ? c.subscribersActive - dec : 0;
        }

        emit LionEvent(
            mainnetCollection,
            tokenId,
            eventType,
            msg.sender,
            payload,
            bytes(""),
            uint64(block.timestamp)
        );
    }

    // --- Internal helpers --------------------------------------------

    /// @dev Absolute value of an int32 as uint32. Safe: int32 min
    ///      (-2_147_483_648) maps to 2_147_483_648 which fits in uint32.
    function _absI32(int32 v) private pure returns (uint32) {
        if (v >= 0) return uint32(uint256(int256(v)));
        // -int256(v) is safe because v is int32 (much smaller than int256 min)
        return uint32(uint256(-int256(v)));
    }

    // --- Reads -------------------------------------------------------

    /// @inheritdoc ILionLedger
    function counters(address mainnetCollection, uint256 tokenId)
        external
        view
        returns (Counters memory)
    {
        return _counters[mainnetCollection][tokenId];
    }
}
