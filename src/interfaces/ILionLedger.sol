// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILionLedger
/// @notice Append-only activity log for Lions. Source of truth for
///         everything that happens after a Lion is bound as an agent.
///         Lives on Base; readable by the EvolutionOracle and any
///         external indexer.
interface ILionLedger {
    /// @notice Canonical event categories. New categories can be added
    ///         by the operator without storage changes. they just emit
    ///         under EventType.Custom with a category string.
    enum EventType {
        PickMade,
        PickSettled,
        JournalEntry,
        SwarmVerdict,
        LevelEarned,
        ArtMinted,
        SubscriptionStarted,
        SubscriptionRenewed,
        SubscriptionEnded,
        ToolAuthorized,
        Custom
    }

    /// @notice Emitted on every write. Indexers consume these to build
    ///         per-Lion timelines.
    /// @param mainnetCollection The mainnet NFT collection address (Lions = 0x8943…)
    /// @param tokenId The Lion's mainnet token id
    /// @param eventType Category enum
    /// @param submitter The wallet that submitted (operator or holder)
    /// @param payload Free-form bytes. typically a Merkle root or hash
    ///                of the off-chain artifact this event commemorates
    /// @param metadata Free-form bytes. optional inline data (small)
    event LionEvent(
        address indexed mainnetCollection,
        uint256 indexed tokenId,
        EventType indexed eventType,
        address submitter,
        bytes32 payload,
        bytes metadata,
        uint64 timestamp
    );

    /// @notice Per-Lion counter snapshot. Used by the evolution oracle
    ///         to compute earned level deterministically.
    struct Counters {
        uint32 picksMade;
        uint32 picksSettled;
        uint32 picksWon;
        uint32 journalEntries;
        uint32 swarmVerdicts;
        uint32 artMinted;
        uint32 subscribersTotal;
        uint32 subscribersActive;
        uint32 toolsAuthorized;
        uint64 firstSeenAt;
        uint64 lastEventAt;
    }

    /// @notice Read the current counters for a Lion. Called by the
    ///         EvolutionOracle and the agent art renderer.
    function counters(address mainnetCollection, uint256 tokenId)
        external
        view
        returns (Counters memory);

    /// @notice Submit a single event. Restricted to authorized operators.
    function record(
        address mainnetCollection,
        uint256 tokenId,
        EventType eventType,
        bytes32 payload,
        bytes calldata metadata
    ) external;

    /// @notice Submit a pick outcome. Updates picksSettled + picksWon.
    function recordPickSettled(
        address mainnetCollection,
        uint256 tokenId,
        bool won,
        bytes32 payload,
        bytes calldata metadata
    ) external;

    /// @notice Subscription lifecycle helper called by LionSubscription.
    function recordSubscriptionChange(
        address mainnetCollection,
        uint256 tokenId,
        int32 activeDelta,
        EventType eventType,
        bytes32 payload
    ) external;
}
