// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILionRenderer
/// @notice Pure-Solidity SVG renderer for Lion art pieces. Stateless;
///         deterministic; composable by any contract.
///
/// Given a Lion's base bitmap, current level, and a snapshot of
/// activity-derived inputs, returns the full SVG bytes for a layered
/// generative art piece. The art is genuinely on chain — the renderer
/// has no external dependencies, no IPFS, no off-chain calls.
interface ILionRenderer {
    /// @notice Inputs needed to render one piece. All fields are
    ///         deterministic — same inputs always produce identical
    ///         output bytes.
    struct RenderInputs {
        /// Lion bitmap at the time of mint (25 bytes packed)
        bytes bitmap;
        /// Lion level at the time of mint
        uint8 level;
        /// 32-byte seed derived from activity counters (used for
        /// background generative pixels)
        bytes32 activitySeed;
        /// What kind of event this art commemorates
        uint8 eventKind;
        /// Free-form event-specific data (e.g. swarm vote tally)
        bytes32 eventData;
        /// Display name to show in the frame
        string name;
        /// Token id from the mainnet Lion this art is bound to
        uint256 mainnetTokenId;
    }

    /// @notice Render the full SVG for a piece. Returns raw SVG bytes
    ///         (no data URI wrapping) so callers can wrap as needed.
    function renderSVG(RenderInputs calldata inputs)
        external
        pure
        returns (string memory);

    /// @notice Convenience: returns a `data:image/svg+xml;base64,…` URI.
    function renderDataURI(RenderInputs calldata inputs)
        external
        pure
        returns (string memory);
}
